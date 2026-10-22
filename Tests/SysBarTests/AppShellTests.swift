import AppKit
import XCTest
@testable import SysBar

@MainActor
final class AppShellTests: XCTestCase {
    func testHiddenMainMenuKeepsStandardEditingShortcutsForTheSearchField() throws {
        let menu = MainMenu.make()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        func item(_ action: String) throws -> NSMenuItem {
            try XCTUnwrap(items.first { $0.action == NSSelectorFromString(action) }, action)
        }

        XCTAssertEqual(try item("copy:").keyEquivalent, "c")
        XCTAssertEqual(try item("paste:").keyEquivalent, "v")
        XCTAssertEqual(try item("cut:").keyEquivalent, "x")
        XCTAssertEqual(try item("selectAll:").keyEquivalent, "a")
        XCTAssertEqual(try item("undo:").keyEquivalent, "z")
        XCTAssertEqual(try item("redo:").keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(try item("terminate:").keyEquivalent, "q")
    }

    func testReopeningWithoutAMonitorOpensNoWindow() {
        XCTAssertFalse(AppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    }
}
