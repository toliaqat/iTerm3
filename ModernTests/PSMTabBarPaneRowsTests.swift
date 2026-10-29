//
//  PSMTabBarPaneRowsTests.swift
//  ModernTests
//
//  A vertical tab bar can list a tab's split panes in rows beneath it. The rows
//  live in the tab's slot below its one-row cell frame, so these check that the
//  slot grows by one row per pane and that hit-testing maps points to the right
//  pane, and only on a vertical bar.
//

import XCTest
@testable import iTerm2SharedARC

final class PSMTabBarPaneRowsTests: XCTestCase {
    private var control: PSMTabBarControl!

    override func setUp() {
        super.setUp()
        control = PSMTabBarControl(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        control.style.tabBar = control
        control.orientation = .verticalOrientation
    }

    override func tearDown() {
        control = nil
        super.tearDown()
    }

    private func addCell(atY y: CGFloat, paneTitles: [String]?) -> PSMTabBarCell {
        let cell = PSMTabBarCell(controlView: control)!
        cell.frame = NSRect(x: 0, y: y, width: 200, height: control.verticalSlotHeight(for: cell))
        cell.paneTitles = paneTitles
        control.cells().add(cell)
        return cell
    }

    func testSlotGrowsByOneRowPerPane() {
        let plain = addCell(atY: 0, paneTitles: nil)
        let tabHeight = control.verticalSlotHeight(for: plain)
        let split = addCell(atY: tabHeight, paneTitles: ["a", "b", "c"])

        let rowHeight = control.frameOfPaneRow(at: 0, of: split).height
        XCTAssertGreaterThan(rowHeight, 0)
        XCTAssertEqual(control.verticalSlotHeight(for: split), tabHeight + 3 * rowHeight)
    }

    func testHitTestFindsPaneRowBelowTabRow() {
        let cell = addCell(atY: 10, paneTitles: ["left", "right"])
        let second = control.frameOfPaneRow(at: 1, of: cell)

        var index = NSNotFound
        let hit = control.cellForPaneRow(at: NSPoint(x: second.midX, y: second.midY), paneIndex: &index)
        XCTAssertTrue(hit === cell)
        XCTAssertEqual(index, 1)

        // The tab row itself is not a pane row.
        XCTAssertNil(control.cellForPaneRow(at: NSPoint(x: 50, y: cell.frame.minY + 1), paneIndex: nil))
    }

    func testHorizontalBarHasNoPaneRows() {
        let cell = addCell(atY: 0, paneTitles: ["left", "right"])
        let row = control.frameOfPaneRow(at: 0, of: cell)
        control.orientation = .horizontalOrientation

        XCTAssertNil(control.cellForPaneRow(at: NSPoint(x: row.midX, y: row.midY), paneIndex: nil))
    }
}
