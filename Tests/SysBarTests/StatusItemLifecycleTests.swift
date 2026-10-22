import XCTest
@testable import SysBar

@MainActor
final class StatusItemLifecycleTests: XCTestCase {
    func testPopoverViewportCapsGrowingContentAtAComfortableScreenBoundedHeight() {
        let initial = PopoverSizePolicy.contentSize(
            idealHeight: 700,
            visibleFrameHeight: 900
        )
        let populated = PopoverSizePolicy.contentSize(
            idealHeight: 2_400,
            visibleFrameHeight: 900
        )

        XCTAssertEqual(initial.height, 700)
        XCTAssertEqual(populated.height, 720)
        XCTAssertEqual(initial.width, 380)
        XCTAssertEqual(populated.width, 380)
    }

    func testPopoverViewportNeverExceedsASmallVisibleScreen() {
        let size = PopoverSizePolicy.contentSize(
            idealHeight: 2_400,
            visibleFrameHeight: 250
        )

        XCTAssertEqual(size.height, 200)
    }

    func testPopoverViewportUsesMinimumHeightForInvalidIdealSize() {
        let size = PopoverSizePolicy.contentSize(
            idealHeight: .nan,
            visibleFrameHeight: 900
        )

        XCTAssertEqual(size.height, 640)
    }

    func testPopoverOpensAtTheLoadedLayoutHeightEvenBeforeProcessesArrive() {
        let loading = PopoverSizePolicy.contentSize(idealHeight: 380, visibleFrameHeight: 1_100)
        XCTAssertEqual(loading.height, 640)
    }

    func testPopoverViewportDoesNotAutomaticallyTrackGrowingSwiftUIContent() {
        XCTAssertTrue(PopoverSizePolicy.hostingSizingOptions.isEmpty)
    }

    func testInitialStateDoesNotStartPanelSession() {
        let session = PanelSessionSpy()

        _ = StatusItemLifecycle(session: session) { HostToken() }

        XCTAssertEqual(session.openCount, 0)
        XCTAssertEqual(session.closeCount, 0)
    }

    func testDuplicateShowAndCloseCallbacksAreIgnored() {
        let session = PanelSessionSpy()
        let lifecycle = StatusItemLifecycle(session: session) { HostToken() }

        lifecycle.popoverWillShow()
        lifecycle.popoverWillShow()
        lifecycle.popoverDidClose()
        lifecycle.popoverDidClose()

        XCTAssertEqual(session.openCount, 1)
        XCTAssertEqual(session.closeCount, 1)
    }

    func testCloseBeforeFirstShowDoesNothing() {
        let session = PanelSessionSpy()
        let lifecycle = StatusItemLifecycle(session: session) { HostToken() }

        lifecycle.popoverDidClose()

        XCTAssertEqual(session.openCount, 0)
        XCTAssertEqual(session.closeCount, 0)
    }

    func testReopeningStartsASeparateBalancedSession() {
        let session = PanelSessionSpy()
        let lifecycle = StatusItemLifecycle(session: session) { HostToken() }

        lifecycle.popoverWillShow()
        lifecycle.popoverDidClose()
        lifecycle.popoverWillShow()
        lifecycle.popoverDidClose()

        XCTAssertEqual(session.openCount, 2)
        XCTAssertEqual(session.closeCount, 2)
    }

    func testInvalidationClosesOpenSessionExactlyOnce() {
        let session = PanelSessionSpy()
        let lifecycle = StatusItemLifecycle(session: session) { HostToken() }
        lifecycle.popoverWillShow()

        lifecycle.invalidate()
        lifecycle.invalidate()
        lifecycle.popoverDidClose()
        lifecycle.popoverWillShow()

        XCTAssertEqual(session.openCount, 1)
        XCTAssertEqual(session.closeCount, 1)
    }

    func testHostFactoryRunsOnceAcrossOpenCloseCycles() {
        let session = PanelSessionSpy()
        var factoryCount = 0
        let expectedHost = HostToken()
        let lifecycle = StatusItemLifecycle(session: session) {
            factoryCount += 1
            return expectedHost
        }

        lifecycle.popoverWillShow()
        lifecycle.popoverDidClose()
        lifecycle.popoverWillShow()
        lifecycle.popoverDidClose()

        XCTAssertEqual(factoryCount, 1)
        XCTAssertTrue(lifecycle.host === expectedHost)
    }
}

@MainActor
private final class PanelSessionSpy: PanelSessionHandling {
    private(set) var openCount = 0
    private(set) var closeCount = 0

    func panelDidOpen() {
        openCount += 1
    }

    func panelDidClose() {
        closeCount += 1
    }
}

private final class HostToken {}
