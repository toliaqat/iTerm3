//
//  ToolFiles.swift
//  iTerm2SharedARC
//
//  A toolbelt tool that browses the current session's working directory in a
//  tree and shows the selected file in an editor beside it.
//

import AppKit
import UniformTypeIdentifiers

private final class ToolFilesNode: NSObject {
    // Noise that hides what matters, as in most editors’ file trees.
    private static let excludedNames: Set<String> = [".git", ".DS_Store", ".hg", ".svn"]

    let url: URL
    let isDirectory: Bool
    private var cachedChildren: [ToolFilesNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    // Read on first expansion and cached; folders first, then Finder order.
    var children: [ToolFilesNode] {
        if let cachedChildren {
            return cachedChildren
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: url,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsPackageDescendants])) ?? []
        let nodes = urls.compactMap { childURL -> ToolFilesNode? in
            if Self.excludedNames.contains(childURL.lastPathComponent) {
                return nil
            }
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return ToolFilesNode(url: childURL, isDirectory: isDirectory)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        cachedChildren = nodes
        return nodes
    }
}

private final class ToolFilesCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.it_toolbelt()
        textField.lineBreakMode = .byTruncatingMiddle
        addSubview(imageView)
        addSubview(textField)
        self.imageView = imageView
        self.textField = textField
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let iconSize = 16.0
        imageView?.frame = NSRect(x: 0, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        if let textField {
            let height = ceil(textField.intrinsicContentSize.height)
            let x = iconSize + 4
            textField.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 2), height: height)
        }
    }
}

@objc(ToolFiles)
class ToolFiles: NSView, ToolbeltTool, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
    private static let headerHeight = 23.0
    private static let treeWidth = 220.0
    // How wide the toolbelt should be for the tree and an editor to fit side by side.
    private static let comfortableWidth = 720.0

    private let pathField = NSTextField(labelWithString: "")
    private var upButton: NSButton!
    private var reloadButton: NSButton!
    private let splitView = NSSplitView()
    private let treeScrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let editor = ToolFilesEditorView(frame: .zero)
    private var root: ToolFilesNode?
    // Where the shell is, as opposed to `root`, which the user can move.
    private var sessionDirectory: String?
    private var iconCache = [String: NSImage]()
    private var ignoreSelectionChange = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        upButton = makeToolbeltButton(imageName: SFSymbol.arrowUp.rawValue,
                                      title: String(localized: "ToolFiles.EnclosingFolder", defaultValue: "Enclosing Folder", comment: "Toolbelt Files tool button that shows the parent folder"),
                                      target: self,
                                      selector: #selector(goUp(_:)),
                                      frame: frameRect)
        upButton.toolTip = String(localized: "ToolFiles.EnclosingFolder", defaultValue: "Enclosing Folder", comment: "Toolbelt Files tool button that shows the parent folder")
        reloadButton = makeToolbeltButton(imageName: SFSymbol.arrowClockwise.rawValue,
                                          title: String(localized: "ToolFiles.Reload", defaultValue: "Reload", comment: "Toolbelt Files tool button that rereads the folder"),
                                          target: self,
                                          selector: #selector(reload(_:)),
                                          frame: frameRect)
        reloadButton.toolTip = String(localized: "ToolFiles.Reload", defaultValue: "Reload", comment: "Toolbelt Files tool button that rereads the folder")
        addSubview(upButton)
        addSubview(reloadButton)

        pathField.font = NSFont.it_toolbelt()
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingHead
        addSubview(pathField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 10
        outlineView.autoresizesOutlineColumn = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(didClickRow(_:))
        outlineView.doubleAction = #selector(didDoubleClickRow(_:))
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        treeScrollView.documentView = outlineView
        treeScrollView.hasVerticalScroller = true
        treeScrollView.autohidesScrollers = true
        treeScrollView.drawsBackground = false
        treeScrollView.borderType = .noBorder

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addSubview(treeScrollView)
        addSubview(splitView)

        relayout()
    }

    required init!(frame: NSRect, url: URL!, identifier: String!) {
        it_fatalError()
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    static func isDynamic() -> Bool {
        return false
    }

    static var supportedProfileTypes: ProfileType {
        ProfileType.terminal
    }

    @objc func shutdown() {
    }

    @objc func minimumHeight() -> CGFloat {
        return 120.0
    }

    @objc override var isFlipped: Bool { true }

    @objc override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout()
    }

    @objc func relayout() {
        let height = Self.headerHeight
        var x = frame.width
        for button in [reloadButton!, upButton!] {
            button.sizeToFit()
            x -= button.frame.width + 2
            button.frame = NSRect(x: x, y: 0, width: button.frame.width, height: height)
        }
        let fieldHeight = ceil(pathField.intrinsicContentSize.height)
        pathField.frame = NSRect(x: 4,
                                 y: (height - fieldHeight) / 2,
                                 width: max(0, x - 8),
                                 height: fieldHeight)
        splitView.frame = NSRect(x: 0, y: height + 2, width: frame.width, height: max(0, frame.height - height - 2))
    }

    // MARK: - Following the session

    // Follow the current session's folder. Does nothing if it hasn't changed, so
    // expansion, scrolling, and the open file survive unrelated refreshes.
    @objc func currentDirectoryDidChange() {
        guard let directory = toolWrapper()?.delegate?.delegate?.toolbeltCurrentWorkingDirectory(),
              !directory.isEmpty,
              directory != sessionDirectory else {
            return
        }
        sessionDirectory = directory
        show(path: directory)
    }

    private func show(path: String) {
        root = ToolFilesNode(url: URL(fileURLWithPath: path, isDirectory: true), isDirectory: true)
        pathField.stringValue = (path as NSString).abbreviatingWithTildeInPath
        pathField.toolTip = path
        upButton.isEnabled = path != "/"
        outlineView.reloadData()
        outlineView.scrollRowToVisible(0)
        selectOpenFile()
    }

    @objc private func goUp(_ sender: Any?) {
        guard let root else {
            return
        }
        show(path: root.url.deletingLastPathComponent().path)
    }

    @objc private func reload(_ sender: Any?) {
        // Some shells don’t report every cd, so a reload also catches up with the session.
        if let directory = toolWrapper()?.delegate?.delegate?.toolbeltCurrentWorkingDirectory(),
           !directory.isEmpty,
           directory != sessionDirectory {
            currentDirectoryDidChange()
            return
        }
        guard let root else {
            return
        }
        let expanded = (0..<outlineView.numberOfRows).compactMap { row -> URL? in
            guard let node = outlineView.item(atRow: row) as? ToolFilesNode,
                  outlineView.isItemExpanded(node) else {
                return nil
            }
            return node.url
        }
        show(path: root.url.path)
        // Rows are in display order, so parents are re-expanded before their children.
        for url in expanded {
            if let node = node(for: url) {
                outlineView.expandItem(node)
            }
        }
        selectOpenFile()
        if let url = editor.url, !editor.isDirty {
            editor.open(url)
        }
    }

    private func node(for url: URL) -> ToolFilesNode? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? ToolFilesNode, node.url == url {
                return node
            }
        }
        return nil
    }

    private func selectOpenFile() {
        ignoreSelectionChange = true
        defer {
            ignoreSelectionChange = false
        }
        guard let url = editor.url, let node = node(for: url) else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: node)), byExtendingSelection: false)
    }

    // MARK: - Opening files

    private func open(_ node: ToolFilesNode) {
        if node.url == editor.url {
            return
        }
        guard editor.confirmDiscardingChanges() else {
            selectOpenFile()
            return
        }
        showEditorIfNeeded()
        editor.open(node.url)
    }

    @objc func closeEditor(_ sender: Any?) {
        guard editor.confirmDiscardingChanges() else {
            return
        }
        editor.close()
        editor.removeFromSuperview()
        splitView.adjustSubviews()
        outlineView.deselectAll(nil)
    }

    private func showEditorIfNeeded() {
        guard !isEditorVisible else {
            return
        }
        if let delegate = toolWrapper()?.delegate?.delegate, frame.width < Self.comfortableWidth {
            delegate.growToolbelt(by: Self.comfortableWidth - frame.width)
            delegate.toolbeltDidFinishGrowing()
        }
        editor.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width / 2, height: splitView.bounds.height)
        splitView.addSubview(editor)
        splitView.adjustSubviews()
        splitView.setPosition(min(Self.treeWidth, splitView.bounds.width / 2), ofDividerAt: 0)
    }

    private var isEditorVisible: Bool {
        return editor.superview != nil
    }

    private var clickedNode: ToolFilesNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return outlineView.item(atRow: row) as? ToolFilesNode
    }

    // A single click toggles a folder, like the file tree in most editors.
    @objc private func didClickRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = clickedNode, node.isDirectory else {
            return
        }
        // The disclosure triangle already toggled it.
        if let event = NSApp.currentEvent,
           outlineView.frameOfOutlineCell(atRow: row).contains(outlineView.convert(event.locationInWindow, from: nil)) {
            return
        }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    @objc private func didDoubleClickRow(_ sender: Any?) {
        guard let node = clickedNode, !node.isDirectory else {
            return
        }
        NSWorkspace.shared.open(node.url)
    }

    // MARK: - Context menu

    @objc private func openNode(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ToolFilesNode else {
            return
        }
        NSWorkspace.shared.open(node.url)
    }

    @objc private func revealNode(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ToolFilesNode else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ToolFilesNode else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }

    @objc private func insertPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ToolFilesNode,
              let delegate = toolWrapper()?.delegate?.delegate else {
            return
        }
        let path = node.url.path as NSString
        delegate.toolbeltInsertText(path.withEscapedShellCharacters(includingNewlines: true) + " ")
        delegate.toolbeltMakeCurrentSessionFirstResponder()
    }

    @objc private func showFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? ToolFilesNode else {
            return
        }
        show(path: node.url.path)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = clickedNode else {
            return
        }
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            menu.addItem(item)
        }
        add(String(localized: "ToolFiles.OpenInDefaultApp", defaultValue: "Open in Default App", comment: "Files tool menu item that opens a file in its default app"), #selector(openNode(_:)))
        if node.isDirectory {
            add(String(localized: "ToolFiles.ShowThisFolder", defaultValue: "Show This Folder", comment: "Files tool menu item that makes the folder the tree’s root"), #selector(showFolder(_:)))
        }
        add(String(localized: "ToolFiles.RevealInFinder", defaultValue: "Reveal in Finder", comment: "Files tool menu item that selects the file in Finder"), #selector(revealNode(_:)))
        menu.addItem(.separator())
        add(String(localized: "ToolFiles.CopyPath", defaultValue: "Copy Path", comment: "Files tool menu item that copies the file’s path"), #selector(copyPath(_:)))
        add(String(localized: "ToolFiles.InsertPath", defaultValue: "Insert Path in Terminal", comment: "Files tool menu item that types the file’s path into the terminal"), #selector(insertPath(_:)))
        if isEditorVisible {
            menu.addItem(.separator())
            let item = NSMenuItem(title: String(localized: "ToolFiles.CloseEditor", defaultValue: "Close Editor", comment: "Files tool menu item that hides the editor"),
                                  action: #selector(closeEditor(_:)),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? ToolFilesNode) ?? root else {
            return 0
        }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = (item as? ToolFilesNode) ?? root else {
            it_fatalError("Child requested with no root")
        }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? ToolFilesNode)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ToolFilesNode else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("ToolFilesCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? ToolFilesCellView) ?? ToolFilesCellView(identifier: identifier)
        cell.textField?.stringValue = node.name
        cell.imageView?.image = icon(for: node)
        cell.toolTip = (node.url.path as NSString).abbreviatingWithTildeInPath
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if ignoreSelectionChange {
            return
        }
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? ToolFilesNode, !node.isDirectory else {
            return
        }
        open(node)
    }

    // Icons come from the file type rather than the file so drawing a row never
    // touches the disk.
    private func icon(for node: ToolFilesNode) -> NSImage {
        let key = node.isDirectory ? "/" : node.url.pathExtension.lowercased()
        if let cached = iconCache[key] {
            return cached
        }
        let type: UTType
        if node.isDirectory {
            type = .folder
        } else {
            type = UTType(filenameExtension: key) ?? .data
        }
        let image = NSWorkspace.shared.icon(for: type)
        iconCache[key] = image
        return image
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 120
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return max(120, splitView.bounds.width - 200)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // Keep the tree’s width when the toolbelt resizes; the editor takes up the change.
        return view !== treeScrollView || !isEditorVisible
    }
}
