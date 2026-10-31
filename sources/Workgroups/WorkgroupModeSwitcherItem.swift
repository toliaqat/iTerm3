//
//  WorkgroupModeSwitcherItem.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/24/26.
//

import AppKit

protocol WorkgroupModeSwitcherItemDelegate: AnyObject {
    // The user picked a peer from the switcher; `identifier` is the
    // peer session's uniqueIdentifier.
    func workgroupModeSwitcher(_ item: WorkgroupModeSwitcherItem,
                               didSelect identifier: String)
}

// An NSSegmentedControl-backed toolbar item whose segments are a
// workgroup peer group's members. Segments carry the peers'
// uniqueIdentifiers; the visible label on each is the peer's
// configured displayName.
final class WorkgroupModeSwitcherItem: SessionToolbarControl {
    weak var modeSwitchDelegate: WorkgroupModeSwitcherItemDelegate?
    private let segmentedControl: WorkgroupPeerSegmentedControl
    // Segment index → peer-session unique identifier.
    private var identifiers: [String]

    init(identifier: String,
         priority: Int,
         members: [(identifier: String,
                    label: String,
                    shortcut: WorkgroupToolbarShortcut?)],
         activeIdentifier: String) {
        self.identifiers = members.map { $0.identifier }
        // Segments show only the peer's name to save width. Its
        // activation shortcut goes in the tooltip: a configured
        // `peerSwitchShortcut` if there is one, else the built-in
        // ⌥⇧⌘1..8 (and ⌥⇧⌘9 for the last of nine or more peers).
        let shortcuts = members.enumerated().map { (index, member) -> String? in
            if let custom = member.shortcut,
               let keystroke = custom.keystroke {
                return iTermKeystrokeFormatter.string(for: keystroke)
            }
            return Self.shortcutLabel(forSegmentIndex: index,
                                      total: members.count)
        }
        let labels = members.map { $0.label }
        segmentedControl = WorkgroupPeerSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: nil,
            action: #selector(modeChanged(_:)))
        segmentedControl.segmentStyle = .texturedRounded
        for (index, shortcut) in shortcuts.enumerated() {
            if let shortcut, !shortcut.isEmpty {
                segmentedControl.setToolTip(shortcut, forSegment: index)
            }
        }
        if let idx = identifiers.firstIndex(of: activeIdentifier) {
            segmentedControl.selectedSegment = idx
        }
        super.init(identifier: identifier,
                   priority: priority,
                   control: segmentedControl)
        segmentedControl.target = self
        // Reserving/freeing a busy segment's spinner box changes the
        // control's fitting width; ask the toolbar to re-lay out so the
        // item's desiredWidthRange (which tracks fittingSize) is honored.
        segmentedControl.onReservedWidthChanged = { [weak self] in
            guard let self else { return }
            self.delegate?.itemDidChange(sender: self)
        }
    }

    // Show or hide the activity indicator on the segment for `identifier`.
    // No-op if the identifier isn't one of this switcher's peers.
    func setBusy(_ busy: Bool, forIdentifier identifier: String) {
        guard let idx = identifiers.firstIndex(of: identifier) else { return }
        segmentedControl.setBusy(busy, forSegment: idx)
    }

    // Shortcut suffix for a segment label, or nil if no shortcut maps
    // to this segment. Modifier order matches macOS shortcut display:
    // ⌃⌥⇧⌘ (we have no ⌃, so ⌥⇧⌘).
    private static func shortcutLabel(forSegmentIndex i: Int,
                                      total: Int) -> String? {
        let n = i + 1
        if n <= 8 {
            return "⌥⇧⌘\(n)"
        }
        if n == total {
            return "⌥⇧⌘9"
        }
        return nil
    }


    func setActiveIdentifier(_ identifier: String) {
        if let idx = identifiers.firstIndex(of: identifier) {
            segmentedControl.selectedSegment = idx
        }
    }

    // The identifier whose segment is currently selected, or nil when
    // nothing is. Lets tests (and logs) observe the visual selection
    // the resync paths maintain.
    var selectedIdentifier: String? {
        let idx = segmentedControl.indexOfSelectedItem
        guard idx >= 0, idx < identifiers.count else { return nil }
        return identifiers[idx]
    }

    var segmentCount: Int {
        return identifiers.count
    }

    override var desiredWidthRange: ClosedRange<CGFloat> {
        let natural = max(_view.fittingSize.width, 0)
        return (30.0 * CGFloat(segmentedControl.segmentCount))...natural
    }

    @objc
    private func modeChanged(_ sender: Any?) {
        let idx = segmentedControl.indexOfSelectedItem
        guard idx >= 0, idx < identifiers.count else { return }
        modeSwitchDelegate?.workgroupModeSwitcher(self,
                                                  didSelect: identifiers[idx])
    }
}
