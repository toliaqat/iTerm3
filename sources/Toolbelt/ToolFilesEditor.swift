//
//  ToolFilesEditor.swift
//  iTerm2SharedARC
//
//  The viewer/editor half of the Files toolbelt tool: text with save, rendered
//  Markdown with an edit toggle, and images.
//

import AppKit
import SwiftyMarkdown
import UniformTypeIdentifiers

class ToolFilesEditorView: NSView, NSTextViewDelegate {
    private static let headerHeight = 26.0
    private static let maximumFileSize = 4 * 1024 * 1024

    private enum Content {
        case none
        case text
        case markdown
        case image
        case unsupported
    }

    private let titleField = NSTextField(labelWithString: "")
    private let modeControl: NSSegmentedControl
    private let saveButton: NSButton
    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private let imageScrollView = NSScrollView()
    private let imageView = NSImageView()
    private let messageField = NSTextField(wrappingLabelWithString: "")

    private(set) var url: URL?
    private var content = Content.none
    private var editingMarkdown = false
    // The file’s contents as of the last load or save.
    private var savedText = ""
    private(set) var isDirty = false {
        didSet {
            updateHeader()
        }
    }

    override init(frame frameRect: NSRect) {
        modeControl = NSSegmentedControl(labels: [String(localized: "ToolFiles.Preview", defaultValue: "Preview", comment: "Files tool segment that shows rendered Markdown"),
                                                  String(localized: "ToolFiles.Edit", defaultValue: "Edit", comment: "Files tool segment that shows Markdown source for editing")],
                                         trackingMode: .selectOne,
                                         target: nil,
                                         action: nil)
        saveButton = NSButton(title: String(localized: "ToolFiles.Save", defaultValue: "Save", comment: "Files tool button that saves the open file"),
                              target: nil,
                              action: nil)
        super.init(frame: frameRect)

        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingMiddle
        addSubview(titleField)

        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeDidChange(_:))
        addSubview(modeControl)

        saveButton.controlSize = .small
        saveButton.bezelStyle = .rounded
        saveButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        addSubview(saveButton)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.delegate = self
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        addSubview(scrollView)

        imageView.imageScaling = .scaleProportionallyDown
        imageScrollView.documentView = imageView
        imageScrollView.drawsBackground = false
        imageScrollView.hasVerticalScroller = true
        imageScrollView.hasHorizontalScroller = true
        addSubview(imageScrollView)

        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        addSubview(messageField)

        show(.none)
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        relayout()
    }

    private func relayout() {
        let height = Self.headerHeight
        var x = bounds.width - 4
        for control in [saveButton, modeControl] as [NSControl] where !control.isHidden {
            control.sizeToFit()
            let size = control.frame.size
            x -= size.width
            control.frame = NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            x -= 4
        }
        let titleHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(x: 6, y: (height - titleHeight) / 2, width: max(0, x - 6), height: titleHeight)
        let body = NSRect(x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        scrollView.frame = body
        imageScrollView.frame = body
        if let size = imageView.image?.size {
            imageView.frame = NSRect(x: 0, y: 0, width: max(size.width, body.width - 2), height: max(size.height, body.height - 2))
        }
        let messageHeight = ceil(messageField.sizeThatFits(NSSize(width: body.width - 24, height: .greatestFiniteMagnitude)).height)
        messageField.frame = NSRect(x: 12, y: body.minY + 24, width: max(0, body.width - 24), height: messageHeight)
    }

    // MARK: - Loading

    func open(_ url: URL) {
        self.url = url
        savedText = ""
        isDirty = false
        editingMarkdown = false
        modeControl.selectedSegment = 0

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if (values?.fileSize ?? 0) > Self.maximumFileSize {
            showMessage(String(localized: "ToolFiles.TooLarge", defaultValue: "This file is too large to show here. Double-click it to open it in its default app.", comment: "Files tool message for files over the size limit"))
            return
        }
        if values?.contentType?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            imageView.image = image
            show(.image)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            showMessage(String(localized: "ToolFiles.Unreadable", defaultValue: "This file can’t be read.", comment: "Files tool message when reading a file fails"))
            return
        }
        guard !data.prefix(8192).contains(0), let text = String(data: data, encoding: .utf8) else {
            showMessage(String(localized: "ToolFiles.Binary", defaultValue: "This file isn’t text. Double-click it to open it in its default app.", comment: "Files tool message for binary files"))
            return
        }
        savedText = text
        textView.string = text
        textView.undoManager?.removeAllActions()
        show(Self.isMarkdown(url) ? .markdown : .text)
    }

    func close() {
        url = nil
        savedText = ""
        isDirty = false
        show(.none)
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        return ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased())
    }

    private func showMessage(_ message: String) {
        messageField.stringValue = message
        show(.unsupported)
    }

    private func show(_ content: Content) {
        self.content = content
        scrollView.isHidden = !(content == .text || content == .markdown)
        imageScrollView.isHidden = content != .image
        messageField.isHidden = content != .unsupported
        if content == .none {
            imageView.image = nil
            textView.string = ""
        }
        if content == .markdown && !editingMarkdown {
            showRenderedMarkdown()
        } else if content == .text || content == .markdown {
            showSource()
        }
        updateHeader()
        relayout()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func showSource() {
        let source = textView.string
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.userFixedPitchFont(ofSize: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.typingAttributes = [.font: textView.font!, .foregroundColor: NSColor.textColor]
        if textView.textStorage?.string != source {
            textView.string = source
        }
        textView.textStorage?.setAttributes([.font: textView.font!, .foregroundColor: NSColor.textColor],
                                            range: NSRange(location: 0, length: (source as NSString).length))
    }

    private func showRenderedMarkdown() {
        let markdown = SwiftyMarkdown(string: textView.string)
        let points = NSFont.systemFontSize
        markdown.setFontSizeForAllStyles(with: points)
        markdown.h1.fontSize = round(points * 2)
        markdown.h2.fontSize = round(points * 1.5)
        markdown.h3.fontSize = round(points * 1.3)
        markdown.h4.fontSize = points
        markdown.h5.fontSize = round(points * 0.9)
        markdown.h6.fontSize = round(points * 0.85)
        markdown.code.fontName = (NSFont.userFixedPitchFont(ofSize: points) ?? .monospacedSystemFont(ofSize: points, weight: .regular)).fontName
        markdown.setFontColorForAllStyles(with: .textColor)
        let rendered = markdown.attributedString()
        // Keep the source so that switching back to Edit shows it, and render on top of it.
        let source = textView.string
        textView.isEditable = false
        textView.isRichText = true
        textView.textStorage?.setAttributedString(rendered)
        renderedSource = source
    }

    // The Markdown source behind a rendered preview. While previewing, the text
    // view holds rendered text, so this is what Edit, Save, and dirty checks use.
    private var renderedSource: String?

    private var currentText: String {
        if content == .markdown && !editingMarkdown, let renderedSource {
            return renderedSource
        }
        return textView.string
    }

    @objc private func modeDidChange(_ sender: Any?) {
        let source = currentText
        editingMarkdown = modeControl.selectedSegment == 1
        if editingMarkdown {
            renderedSource = nil
            textView.string = source
            showSource()
            window?.makeFirstResponder(textView)
        } else {
            textView.string = source
            showRenderedMarkdown()
        }
    }

    private func updateHeader() {
        let name = url?.lastPathComponent ?? ""
        titleField.stringValue = isDirty ? "● " + name : name
        titleField.toolTip = url.map { ($0.path as NSString).abbreviatingWithTildeInPath }
        modeControl.isHidden = content != .markdown
        saveButton.isHidden = !(content == .text || content == .markdown)
        saveButton.isEnabled = isDirty
        relayout()
    }

    // MARK: - Saving

    @discardableResult
    @objc func save(_ sender: Any?) -> Bool {
        guard let url, content == .text || content == .markdown else {
            return false
        }
        let text = currentText
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            iTermWarning.show(withTitle: error.localizedDescription,
                              actions: [iTermLocalizedOK()],
                              accessory: nil,
                              identifier: nil,
                              silenceable: .kiTermWarningTypePersistent,
                              heading: String(localized: "ToolFiles.SaveFailed", defaultValue: "Couldn’t Save File", comment: "Title of the alert shown when saving a file from the Files tool fails"),
                              window: window)
            return false
        }
        savedText = text
        isDirty = false
        return true
    }

    // Returns false if the user cancelled. Otherwise any edits are saved or discarded.
    func confirmDiscardingChanges() -> Bool {
        guard isDirty, let url else {
            return true
        }
        let selection = iTermWarning.show(withTitle: String(localized: "ToolFiles.UnsavedMessage", defaultValue: "Your changes will be lost if you don’t save them.", comment: "Body of the alert shown before leaving a file with unsaved changes"),
                                          actions: [String(localized: "ToolFiles.SaveButton", defaultValue: "Save", comment: "Button that saves unsaved changes"),
                                                    String(localized: "ToolFiles.DontSave", defaultValue: "Don’t Save", comment: "Button that discards unsaved changes"),
                                                    iTermLocalizedCancel()],
                                          actionMapping: nil,
                                          accessory: nil,
                                          identifier: nil,
                                          silenceable: .kiTermWarningTypePersistent,
                                          heading: String(localized: "ToolFiles.UnsavedTitle", defaultValue: "Save changes to “\(url.lastPathComponent)”?", comment: "Title of the alert shown before leaving a file with unsaved changes; the placeholder is the file name"),
                                          cancelLabel: iTermLocalizedCancel(),
                                          window: window)
        switch selection {
        case .kiTermWarningSelection0:
            return save(nil)
        case .kiTermWarningSelection1:
            return true
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers == "s",
           let firstResponder = window?.firstResponder as? NSView,
           firstResponder.isDescendant(of: self) {
            save(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        isDirty = textView.string != savedText
    }
}
