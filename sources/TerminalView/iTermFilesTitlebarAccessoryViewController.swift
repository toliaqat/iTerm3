//
//  iTermFilesTitlebarAccessoryViewController.swift
//  iTerm2SharedARC
//
//  A title bar button that shows or hides the Files panel.
//

import AppKit

@objc(iTermFilesTitlebarAccessoryViewController)
class iTermFilesTitlebarAccessoryViewController: NSTitlebarAccessoryViewController {
    private let button: NSButton

    // Whether the panel is showing. Tints the button so it reads as a toggle.
    @objc var isOn = false {
        didSet {
            button.contentTintColor = isOn ? .controlAccentColor : .secondaryLabelColor
        }
    }

    @objc init(target: AnyObject, action: Selector) {
        let title = String(localized: "FilesTitlebarButton.Tooltip", defaultValue: "Show or Hide Files", comment: "Tooltip for the title bar button that toggles the Files panel")
        button = NSButton(image: NSImage.it_image(forSymbolName: SFSymbol.folder.rawValue, accessibilityDescription: title) ?? NSImage(),
                          target: target,
                          action: action)
        button.toolTip = title
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
    }

    required init?(coder: NSCoder) {
        it_fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        button.frame = NSRect(x: 6, y: 2, width: 20, height: 18)
        button.autoresizingMask = [.minYMargin, .maxYMargin]
        container.addSubview(button)
        view = container
    }
}
