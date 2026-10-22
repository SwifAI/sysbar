import XCTest
@testable import SysBar

final class ListenerPresentationTests: XCTestCase {
    private let listeners = [
        ListenSocket(pid: 41, processName: "Web Server", port: 8_080, bindAddress: "*", isTCP: true),
        ListenSocket(pid: 42, processName: "Preview", port: 3_000, bindAddress: "::1", isTCP: true),
        ListenSocket(pid: 43, processName: "Discovery", port: 55_000, bindAddress: "*", isTCP: false),
        ListenSocket(pid: 44, processName: "Local Worker", port: 8_080, bindAddress: "127.0.0.1", isTCP: true)
    ]

    func testEmptySearchPreservesListenerIdentityAndPriorityOrder() {
        let result = ListenerListPresentation.filtered(listeners, query: " \n\t ", scope: .all)
        XCTAssertEqual(result.map(\.id), listeners.map(\.id))
    }

    func testLANScopeIncludesReachableEphemeralUDPWithoutCallingItActionable() {
        let result = ListenerListPresentation.filtered(listeners, query: "", scope: .lan)
        XCTAssertEqual(result.map(\.pid), [41, 43])
        XCTAssertEqual(result.last?.exposure, .lanReachable)
    }

    func testLocalScopeIncludesIPv4AndIPv6Loopback() {
        let result = ListenerListPresentation.filtered(listeners, query: "", scope: .local)
        XCTAssertEqual(result.map(\.pid), [42, 44])
    }

    func testSearchMatchesAllTermsAcrossNameProtocolAndPort() {
        let result = ListenerListPresentation.filtered(listeners, query: "  WEB  tcp 8080 ", scope: .all)
        XCTAssertEqual(result.map(\.pid), [41])
        XCTAssertTrue(ListenerListPresentation.filtered(listeners, query: "web udp", scope: .all).isEmpty)
    }

    func testSearchCanLocatePIDAndCopiedIPv6Endpoint() {
        XCTAssertEqual(
            ListenerListPresentation.filtered(listeners, query: "42", scope: .all).map(\.pid),
            [42]
        )
        XCTAssertEqual(
            ListenerListPresentation.filtered(listeners, query: "[::1]:3000", scope: .all).map(\.pid),
            [42]
        )
    }

    func testSearchRespectsExposureScopeWhenPortsAreShared() {
        let result = ListenerListPresentation.filtered(listeners, query: "8080", scope: .local)
        XCTAssertEqual(result.map(\.pid), [44])
        XCTAssertTrue(ListenerListPresentation.filtered(listeners, query: "preview", scope: .lan).isEmpty)
    }

    func testIPv6AddressesAreUnambiguousWithoutDoubleBrackets() {
        XCTAssertEqual(PortDisplayText.address(bindAddress: "::1", port: 8_080), "[::1]:8080")
        XCTAssertEqual(PortDisplayText.address(bindAddress: "[::1]", port: 8_080), "[::1]:8080")
        XCTAssertEqual(PortDisplayText.address(bindAddress: "fe80::1%en0", port: 80), "[fe80::1%en0]:80")
        XCTAssertEqual(PortDisplayText.address(bindAddress: "127.0.0.1", port: 80), "127.0.0.1:80")
        XCTAssertEqual(PortDisplayText.address(bindAddress: "*", port: 80), "*:80")
    }

    func testIPv6EndpointFormattingIsConsistentInRowsHelpAndNotifications() {
        XCTAssertEqual(
            PortDisplayText.endpoint(transport: "TCP", bindAddress: "::1", port: 8_080),
            "TCP · [::1]:8080"
        )
        XCTAssertTrue(
            PortDisplayText.help(processName: "Preview", pid: 42, bindAddress: "::1", port: 8_080)
                .contains("[::1]:8080")
        )
        XCTAssertTrue(
            PortDisplayText.listenerAlertBody(processName: "Preview", bindAddress: "::1", port: 8_080)
                .contains("[::1]:8080")
        )
    }

    // The listener-row VoiceOver label is byte-identical: "Port <port>, <process>", ungrouped port digits.
    func testPortAccessibilityLabelNamesThePortThenTheProcessWithoutGroupingSeparators() {
        XCTAssertEqual(
            PortDisplayText.accessibilityLabel(port: 8_080, processName: "Preview"),
            "Port 8080, Preview"
        )
        XCTAssertEqual(
            PortDisplayText.accessibilityLabel(port: UInt16.max, processName: "launchd"),
            "Port 65535, launchd"
        )
    }
}
