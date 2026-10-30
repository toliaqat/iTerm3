//
//  iTermTabGroup.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 8/7/26.
//

import AppKit

// A tab group's definition: its identity, name, and color. Identity is a UUID
// (not window-scoped) so a group keeps its identity when dragged into another
// window. The definition is not stored centrally: it rides each member tab
// (PTYTab.tabGroupID / tabGroupName / tabGroupColor). The window controller
// builds one of these on demand from a member tab to answer the tab bar's
// PSMTabGroupDataSource queries. Which tabs belong to the group, and their run
// order, come from the tabs themselves; nothing here holds a tab list.
@objc(iTermTabGroup)
final class iTermTabGroup: NSObject, PSMTabGroup {
    @objc let uniqueIdentifier: String
    @objc let name: String
    @objc let color: NSColor
    // Set when the group is a project: the folder its tabs are about.
    @objc let projectPath: String?

    @objc init(uniqueIdentifier: String, name: String, color: NSColor, projectPath: String? = nil) {
        self.uniqueIdentifier = uniqueIdentifier
        self.name = name
        self.color = color
        self.projectPath = projectPath
        super.init()
    }

    // Colors cycled through for new groups. Concrete sRGB colors rather than
    // system catalog colors, which the tab color picker can't compare.
    @objc static let palette: [NSColor] = [
        0x5b8def,  // blue
        0x9b7bea,  // violet
        0x3fb68b,  // green
        0xe5a13a,  // amber
        0x3ab0c9,  // cyan
        0xe06c75,  // rose
        0xd9779f,  // pink
    ].map { rgb in
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1)
    }
}
