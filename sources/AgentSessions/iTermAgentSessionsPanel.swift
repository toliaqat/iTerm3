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
    // The window's projects. A session in a project's folder is listed under it.
    func agentSessionsPanelProjects(_ panel: iTermAgentSessionsPanel) -> [iTermTabGroup]
}

@objc(iTermAgentSessionsPanel)
final class iTermAgentSessionsPanel: NSView {
    @objc static let headerHeight: CGFloat = 28
    private static let minimumExpandedHeight: CGFloat = 90
    private static let defaultExpandedHeight: CGFloat = 260
    private static let resizeStripHeight: CGFloat = 5
    private static let collapsedKey = "NoSyncAgentSessionsPanelCollapsed"
    private static let heightKey = "NoSyncAgentSessionsPanelHeight"
    private static let collapsedProjectsKey = "NoSyncAgentSessionsCollapsedProjects"
    private static let groupHeaderRowHeight: CGFloat = 30
    private static let sessionRowHeight: CGFloat = 36

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
    private let optionsButton = NSButton()
    private let collapseAllButton = NSButton()
    private let expandAllButton = NSButton()
    private let separator = NSBox()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var sessions = [iTermAgentSession]()
    private var rows = [iTermAgentSessionsRow]()
    private var groupKeys = [String]()
    private var projectsSignature = ""
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
        configureHeaderButton(refreshButton,
                              symbol: .arrowClockwise,
                              title: reloadTitle,
                              action: #selector(reload(_:)))
        configureHeaderButton(collapseAllButton,
                              symbol: .rectangleCompressVertical,
                              title: String(localized: "AgentSessions.CollapseAll",
                                            defaultValue: "Collapse All Groups",
                                            comment: "Button that collapses every group in the Agent Sessions list"),
                              action: #selector(collapseAllGroups(_:)))
        configureHeaderButton(expandAllButton,
                              symbol: .rectangleExpandVertical,
                              title: String(localized: "AgentSessions.ExpandAll",
                                            defaultValue: "Expand All Groups",
                                            comment: "Button that expands every group in the Agent Sessions list"),
                              action: #selector(expandAllGroups(_:)))
        configureHeaderButton(optionsButton,
                              symbol: .ellipsisCircle,
                              title: String(localized: "AgentSessions.Options",
                                            defaultValue: "Options",
                                            comment: "Button that shows a menu of options for the Agent Sessions list"),
                              action: #selector(showOptionsMenu(_:)))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.rowHeight = Self.sessionRowHeight
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

        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(storeDidUpdate(_:)),
                                               name: iTermAgentSessionStore.didUpdateNotification,
                                               object: nil)
        sessions = iTermAgentSessionStore.shared.sessions
        rebuildRows()
        applyTextColor()
        updateEmptyLabel()
        updateChevron()
        updateCount()
    }

    private func configureHeaderButton(_ button: NSButton, symbol: SFSymbol, title: String, action: Selector) {
        button.image = NSImage.it_image(forSymbolName: symbol.rawValue, accessibilityDescription: title)
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = title
        button.target = self
        button.action = action
        header.addSubview(button)
    }

    private func applyTextColor() {
        titleLabel.textColor = textColor.withAlphaComponent(0.7)
        countLabel.textColor = textColor.withAlphaComponent(0.5)
        emptyLabel.textColor = textColor.withAlphaComponent(0.5)
        chevron.contentTintColor = textColor.withAlphaComponent(0.6)
        for button in [refreshButton, optionsButton, collapseAllButton, expandAllButton] {
            button.contentTintColor = textColor.withAlphaComponent(0.6)
        }
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
        optionsButton.frame = NSRect(x: refreshButton.frame.minX - 22, y: midY - 8, width: 16, height: 16)
        // Group buttons are hidden while the list is hidden or has no groups.
        let showGroupButtons = !collapsed && !groupKeys.isEmpty
        collapseAllButton.isHidden = !showGroupButtons
        expandAllButton.isHidden = !showGroupButtons
        expandAllButton.frame = NSRect(x: optionsButton.frame.minX - 22, y: midY - 8, width: 16, height: 16)
        collapseAllButton.frame = NSRect(x: expandAllButton.frame.minX - 22, y: midY - 8, width: 16, height: 16)
        let countTrailingEdge = showGroupButtons ? collapseAllButton.frame.minX : optionsButton.frame.minX
        countLabel.sizeToFit()
        let countWidth = countLabel.frame.width
        countLabel.frame = NSRect(x: countTrailingEdge - 6 - countWidth,
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
        rebuildRows()
        updateCount()
        updateEmptyLabel()
        needsLayout = true
    }

    // Call when the window's projects may have changed.
    @objc func projectsDidChange() {
        guard Self.signature(of: currentProjects()) != projectsSignature else {
            return
        }
        rebuildRows()
    }

    private static func signature(of projects: [iTermTabGroup]) -> String {
        return projects.map { project in
            [project.uniqueIdentifier, project.name, project.projectPath ?? "", project.color.description].joined(separator: "\u{1}")
        }.joined(separator: "\u{2}")
    }

    private func currentProjects() -> [iTermTabGroup] {
        return (delegate?.agentSessionsPanelProjects(self) ?? []).filter { !($0.projectPath ?? "").isEmpty }
    }

    @objc private func reload(_ sender: Any?) {
        iTermAgentSessionStore.shared.refresh()
    }

    @objc private func showOptionsMenu(_ sender: Any?) {
        let menu = NSMenu()
        let current = iTermAgentSessionStore.shared.timeRange
        for range in iTermAgentSessionStore.TimeRange.allCases {
            let item = NSMenuItem(title: Self.menuTitle(for: range),
                                  action: #selector(selectTimeRange(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = range.rawValue
            item.state = range == current ? .on : .off
            menu.addItem(item)
        }
        // The panel is flipped, so maxY is the bottom edge of the button.
        let anchor = convert(optionsButton.frame, from: header)
        menu.popUp(positioning: nil,
                   at: NSPoint(x: anchor.minX, y: anchor.maxY + 4),
                   in: self)
    }

    @objc private func selectTimeRange(_ sender: NSMenuItem) {
        guard let range = iTermAgentSessionStore.TimeRange(rawValue: sender.tag) else {
            return
        }
        iTermAgentSessionStore.shared.timeRange = range
    }

    private static func menuTitle(for range: iTermAgentSessionStore.TimeRange) -> String {
        switch range {
        case .pastWeek:
            return String(localized: "AgentSessions.Range.PastWeek",
                          defaultValue: "Sessions from the Past 7 Days",
                          comment: "Menu item that limits the Agent Sessions list to the past 7 days")
        case .pastMonth:
            return String(localized: "AgentSessions.Range.PastMonth",
                          defaultValue: "Sessions from the Past 30 Days",
                          comment: "Menu item that limits the Agent Sessions list to the past 30 days")
        }
    }

    private func updateEmptyLabel() {
        switch iTermAgentSessionStore.shared.timeRange {
        case .pastWeek:
            emptyLabel.stringValue = String(localized: "AgentSessions.EmptyPastWeek",
                                            defaultValue: "No sessions in the last 7 days",
                                            comment: "Shown when there are no Copilot or Claude Code sessions from the past 7 days")
        case .pastMonth:
            emptyLabel.stringValue = String(localized: "AgentSessions.Empty",
                                            defaultValue: "No sessions in the last 30 days",
                                            comment: "Shown when there are no recent Copilot or Claude Code sessions")
        }
        needsLayout = true
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

    // MARK: - Grouping

    private var collapsedProjects: Set<String> {
        get { Set(iTermUserDefaults.userDefaults().stringArray(forKey: Self.collapsedProjectsKey) ?? []) }
        set { iTermUserDefaults.userDefaults().set(Array(newValue).sorted(), forKey: Self.collapsedProjectsKey) }
    }

    private func toggleGroup(_ group: iTermAgentSessionGroup) {
        var collapsed = collapsedProjects
        if collapsed.contains(group.key) {
            collapsed.remove(group.key)
        } else {
            collapsed.insert(group.key)
        }
        collapsedProjects = collapsed
        rebuildRows()
    }

    @objc private func collapseAllGroups(_ sender: Any?) {
        collapsedProjects = collapsedProjects.union(groupKeys)
        rebuildRows()
    }

    @objc private func expandAllGroups(_ sender: Any?) {
        collapsedProjects = collapsedProjects.subtracting(groupKeys)
        rebuildRows()
    }

    private func rebuildRows() {
        let projects = currentProjects()
        projectsSignature = Self.signature(of: projects)
        let groups = iTermAgentSessionGroup.groups(for: sessions, projects: projects)
        groupKeys = groups.map(\.key)
        needsLayout = true
        let collapsed = collapsedProjects
        var result = [iTermAgentSessionsRow]()
        for group in groups {
            group.collapsed = collapsed.contains(group.key)
            result.append(.header(group))
            guard !group.collapsed else {
                continue
            }
            for (i, session) in group.sessions.enumerated() {
                result.append(.session(session, isLast: i == group.sessions.count - 1, group: group))
            }
        }
        rows = result
        tableView.reloadData()
    }

    // MARK: - Actions

    @objc private func rowClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else {
            return
        }
        switch rows[row] {
        case .header(let group):
            toggleGroup(group)
        case .session(let session, _, _):
            delegate?.agentSessionsPanel(self, openSession: session)
        }
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
        guard row >= 0, row < rows.count, case .session(let session, _, _) = rows[row] else {
            return nil
        }
        return session
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
        return rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return Self.groupHeaderRowHeight
        case .session: return Self.sessionRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .session = rows[row] {
            return true
        }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let dark = effectiveAppearance.it_isDark
        switch rows[row] {
        case .header(let group):
            let identifier = NSUserInterfaceItemIdentifier("AgentSessionGroupHeader")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? iTermAgentSessionGroupHeaderView)
                ?? iTermAgentSessionGroupHeaderView(identifier: identifier)
            cell.configure(group: group, dark: dark)
            return cell
        case .session(let session, let isLast, let group):
            let identifier = NSUserInterfaceItemIdentifier("AgentSessionCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? iTermAgentSessionCellView)
                ?? iTermAgentSessionCellView(identifier: identifier)
            cell.configure(session: session, group: group, isLast: isLast, textColor: textColor, dark: dark)
            return cell
        }
    }
}

private enum iTermAgentSessionsRow {
    case header(iTermAgentSessionGroup)
    case session(iTermAgentSession, isLast: Bool, group: iTermAgentSessionGroup)
}

// Sessions that share a project: a project of the window that contains their
// folder, or else their repository (or folder).
final class iTermAgentSessionGroup {
    let key: String
    let name: String
    let path: String?
    let color: NSColor
    var sessions = [iTermAgentSession]()
    var collapsed = false

    init(key: String, name: String, path: String?, color: NSColor) {
        self.key = key
        self.name = name
        self.path = path
        self.color = color
    }

    // Groups ordered by their most recent session. `sessions` must already be
    // ordered most recent first.
    static func groups(for sessions: [iTermAgentSession], projects: [iTermTabGroup]) -> [iTermAgentSessionGroup] {
        let projectPaths = projects.map { (project: $0, path: ($0.projectPath! as NSString).standardizingPath) }
        var byKey = [String: iTermAgentSessionGroup]()
        var ordered = [iTermAgentSessionGroup]()
        for session in sessions {
            let group: iTermAgentSessionGroup
            let directory = session.workingDirectory.map { ($0 as NSString).standardizingPath }
            let project = directory.flatMap { directory in
                projectPaths
                    .filter { directory == $0.path || directory.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
                    .max { $0.path.count < $1.path.count }
            }
            let key = project.map { "project:" + $0.path } ?? session.projectRoot.map { ($0 as NSString).standardizingPath } ?? ""
            if let existing = byKey[key] {
                group = existing
            } else if let project {
                group = iTermAgentSessionGroup(key: key, name: project.project.name, path: project.path, color: project.project.color)
                byKey[key] = group
                ordered.append(group)
            } else {
                group = iTermAgentSessionGroup(key: key, name: displayName(for: key), path: key.isEmpty ? nil : key, color: color(for: key))
                byKey[key] = group
                ordered.append(group)
            }
            group.sessions.append(session)
        }
        return ordered
    }

    private static func displayName(for path: String) -> String {
        if path.isEmpty {
            return String(localized: "AgentSessions.UnknownFolder", defaultValue: "Unknown Folder", comment: "Group of agent sessions whose working folder isn’t known")
        }
        if path == NSHomeDirectory() {
            return "~"
        }
        return (path as NSString).lastPathComponent
    }

    // A stable palette color so a folder keeps its color between launches.
    private static func color(for path: String) -> NSColor {
        let palette = iTermTabGroup.palette
        var hash: UInt64 = 5381
        for byte in path.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    // The group color as text or strokes: brightened on a dark background and
    // darkened on a light one, like the tab bar's group headers.
    static func accentColor(_ color: NSColor, dark: Bool) -> NSColor {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        if dark {
            return srgb.blended(withFraction: 0.15, of: .white) ?? srgb
        }
        return srgb.blended(withFraction: 0.3, of: .black) ?? srgb
    }
}

// A project's header: a tinted rounded block with its name, session count, and
// a disclosure chevron, matching the tab bar's group headers.
private final class iTermAgentSessionGroupHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var color = NSColor.clear
    private var dark = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.alignment = .right
        chevron.imageScaling = .scaleProportionallyDown
        for view in [label, countLabel, chevron] {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    func configure(group: iTermAgentSessionGroup, dark: Bool) {
        color = group.color
        self.dark = dark
        let accent = iTermAgentSessionGroup.accentColor(group.color, dark: dark)
        label.stringValue = group.name
        label.textColor = accent
        countLabel.stringValue = "\(group.sessions.count)"
        countLabel.textColor = accent.withAlphaComponent(0.8)
        let symbol = group.collapsed ? SFSymbol.chevronRight : SFSymbol.chevronDown
        chevron.image = NSImage.it_image(forSymbolName: symbol.rawValue, accessibilityDescription: nil)
        chevron.contentTintColor = accent
        toolTip = group.path.map { ($0 as NSString).abbreviatingWithTildeInPath }
        needsDisplay = true
        needsLayout = true
    }

    private var blockRect: NSRect {
        return NSInsetRect(bounds, 4, 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(dark ? 0.22 : 0.16).setFill()
        NSBezierPath(roundedRect: blockRect, xRadius: 6, yRadius: 6).fill()
    }

    override func layout() {
        super.layout()
        let block = blockRect
        let midY = block.midY
        chevron.frame = NSRect(x: block.maxX - 18, y: midY - 5, width: 10, height: 10)
        countLabel.sizeToFit()
        let countSize = countLabel.frame.size
        countLabel.frame = NSRect(x: chevron.frame.minX - 6 - countSize.width,
                                  y: midY - countSize.height / 2,
                                  width: countSize.width,
                                  height: countSize.height)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: block.minX + 8,
                             y: midY - labelHeight / 2,
                             width: max(0, countLabel.frame.minX - block.minX - 14),
                             height: labelHeight)
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
    private var railColor = NSColor.clear
    private var isLast = false
    private static let leadingInset: CGFloat = 18

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

    func configure(session: iTermAgentSession,
                   group: iTermAgentSessionGroup,
                   isLast: Bool,
                   textColor: NSColor,
                   dark: Bool) {
        railColor = iTermAgentSessionGroup.accentColor(group.color, dark: dark)
        self.isLast = isLast
        needsDisplay = true
        titleLabel.stringValue = session.title
        titleLabel.textColor = textColor
        ageLabel.stringValue = iTermAgentSessionsPanel.ageString(since: session.lastActive)
        ageLabel.textColor = textColor.withAlphaComponent(0.55)
        // The group names the project, so only show a folder beneath it.
        var detail = session.agentName
        if let directory = session.workingDirectory.map({ ($0 as NSString).standardizingPath }),
           directory != group.path {
            if let root = group.path, directory.hasPrefix(root + "/") {
                detail += " · " + String(directory.dropFirst(root.count + 1))
            } else {
                detail += " · " + (directory as NSString).abbreviatingWithTildeInPath
            }
        }
        detailLabel.stringValue = detail
        detailLabel.textColor = textColor.withAlphaComponent(0.55)
        toolTip = [session.title, session.workingDirectory, session.resumeCommand]
            .compactMap { $0 }
            .joined(separator: "\n")
        needsLayout = true
    }

    // A thin rail along the group's sessions, like the tab bar's group rail.
    override func draw(_ dirtyRect: NSRect) {
        let bottomInset: CGFloat = isLast ? 4 : 0
        let rail = NSRect(x: 6, y: bottomInset, width: 2.5, height: bounds.height - bottomInset)
        railColor.setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1.25, yRadius: 1.25).fill()
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let leading = Self.leadingInset
        let width = bounds.width
        ageLabel.sizeToFit()
        let ageWidth = ageLabel.frame.width
        let titleHeight = titleLabel.intrinsicContentSize.height
        let detailHeight = detailLabel.intrinsicContentSize.height
        let top = max(0, (bounds.height - titleHeight - detailHeight) / 2)
        // NSTableCellView isn't flipped, so place the title above the detail.
        let titleY = bounds.height - top - titleHeight
        ageLabel.frame = NSRect(x: width - inset - ageWidth, y: titleY, width: ageWidth, height: titleHeight)
        titleLabel.frame = NSRect(x: leading, y: titleY, width: max(0, ageLabel.frame.minX - leading - 6), height: titleHeight)
        detailLabel.frame = NSRect(x: leading, y: titleY - detailHeight, width: max(0, width - leading - inset), height: detailHeight)
    }
}
